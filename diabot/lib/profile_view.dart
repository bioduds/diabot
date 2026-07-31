import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_theme.dart';
import 'events.dart';
import 'profile_engine.dart';

class ProfileViewItem {
  const ProfileViewItem({
    required this.field,
    required this.priority,
    required this.label,
    required this.text,
  });

  final String field;
  final int priority;
  final String label;
  final String text;
}

/// Read-only, priority-sorted projection of the Profile Engine snapshot.
/// Unknown facts never become rows in this projection.
class ProfileViewProjection {
  const ProfileViewProjection({
    required this.generalItems,
    required this.priorityItems,
    required this.photoUrl,
    required this.completenessScore,
  });

  final List<ProfileViewItem> generalItems;
  final List<List<ProfileViewItem>> priorityItems;
  final String? photoUrl;
  final int completenessScore;

  List<ProfileViewItem> get items => [
        ...generalItems,
        for (final group in priorityItems) ...group,
      ];

  factory ProfileViewProjection.fromProfile(ProfileContext profile) {
    final generalItems = _itemsForFields(
      profile,
      FsmContract.profileViewGeneralFields,
      priority: 0,
    );
    final priorityItems = <List<ProfileViewItem>>[];
    for (var priority = 0;
        priority < FsmContract.profileViewPriorityGroups.length;
        priority++) {
      priorityItems.add(_itemsForFields(
        profile,
        FsmContract.profileViewPriorityGroups[priority],
        priority: priority + 1,
      ));
    }
    return ProfileViewProjection(
      generalItems: List.unmodifiable(generalItems),
      priorityItems: List.unmodifiable(
        priorityItems.map(List<ProfileViewItem>.unmodifiable),
      ),
      photoUrl: _knownPhotoUrl(profile.value('photoUrl')),
      completenessScore: profile.completenessScore,
    );
  }

  static List<ProfileViewItem> _itemsForFields(
    ProfileContext profile,
    List<String> fields, {
    required int priority,
  }) {
    final items = <ProfileViewItem>[];
    for (final field in fields) {
      final value = profile.value(field);
      if (value == null || !_isKnown(value)) continue;
      for (final text in _displayValues(field, value)) {
        if (text.trim().isEmpty) continue;
        items.add(ProfileViewItem(
          field: field,
          priority: priority,
          label: _labelFor(field),
          text: '${_labelFor(field)}: $text',
        ));
      }
    }
    return items;
  }

  static String? _knownPhotoUrl(Object? value) =>
      value is String && _isKnown(value) ? value.trim() : null;

  static bool _isKnown(Object value) {
    if (value is String) {
      final normalized = value.trim().toLowerCase();
      return normalized.isNotEmpty &&
          normalized != '?' &&
          normalized != 'null' &&
          normalized != 'unknown' &&
          normalized != 'desconhecido';
    }
    if (value is num) return value.isFinite;
    return true;
  }

  static Iterable<String> _displayValues(String field, Object value) {
    final text = value.toString().trim();
    switch (field) {
      case 'weightKg':
        return ['${_formatNumber(value)} kg'];
      case 'heightCm':
        return ['${_formatNumber(value)} cm'];
      case 'ageYears':
        return ['${_formatNumber(value)} anos'];
      case 'insulinTypes':
        return text.split(',').map((entry) => entry.trim());
      case 'insulinCarbRatio':
        return [text];
      case 'correctionFactor':
        return [text];
      case 'hypoglycemiaUnawareness':
        return value == true ? const ['Sim'] : const ['Não'];
      case 'diagnosisDuration':
        return [text];
      case 'knowledgeLevel':
        return [text];
      case 'interactionMode':
        return [text];
      case 'sex':
        return [text];
      case 'insulinPump':
        return [text];
      default:
        return [text];
    }
  }

  static String _labelFor(String field) => switch (field) {
        'name' => 'Nome',
        'email' => 'E-mail',
        'photoUrl' => 'Foto do perfil',
        'diabetesType' => 'Tipo de diabetes',
        'weightKg' => 'Peso',
        'heightCm' => 'Altura',
        'ageYears' => 'Idade',
        'sex' => 'Sexo',
        'cgm' => 'CGM',
        'insulinPump' => 'Bomba de insulina',
        'insulinTypes' => 'Insulinas',
        'insulinCarbRatio' => 'ICR',
        'correctionFactor' => 'Fator de correção',
        'hypoglycemiaUnawareness' => 'Hipoglicemia não percebida',
        'diagnosisDuration' => 'Tempo desde o diagnóstico',
        'knowledgeLevel' => 'Conhecimento sobre diabetes',
        'interactionMode' => 'Modo de interação',
        'exerciseProfile' => 'Perfil de exercício',
        'mealPatterns' => 'Padrões de refeição',
        'insulinUsagePatterns' => 'Padrões de uso de insulina',
        'learnedFacts' => 'Informações aprendidas',
        _ => field,
      };

  static String _formatNumber(Object value) {
    if (value is num) {
      return value == value.roundToDouble()
          ? value.toStringAsFixed(0)
          : value.toString();
    }
    return value.toString().trim();
  }
}

class ProfileViewPage extends StatefulWidget {
  const ProfileViewPage({super.key, required this.profileEngine});

  final ProfileEngine profileEngine;

  @override
  State<ProfileViewPage> createState() => _ProfileViewPageState();
}

class _ProfileViewPageState extends State<ProfileViewPage> {
  late Future<ProfileEnrichment> _profileFuture;

  @override
  void initState() {
    super.initState();
    _profileFuture = widget.profileEngine.enrich(const []);
  }

  void _refresh() {
    setState(() => _profileFuture = widget.profileEngine.enrich(const []));
  }

  Future<void> _selectPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Tirar foto'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Escolher da galeria'),
              onTap: () => Navigator.of(sheetContext).pop(ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final image = await ImagePicker().pickImage(
      source: source,
      maxWidth: 1200,
      imageQuality: 85,
    );
    if (image == null) return;

    final directory = await getApplicationDocumentsDirectory();
    final extension = path.extension(image.path).isEmpty
        ? '.jpg'
        : path.extension(image.path);
    final saved = await File(image.path).copy(path.join(
      directory.path,
      'profile-photo$extension',
    ));
    await widget.profileEngine.saveLocalPhoto(saved.path);
    if (mounted) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Perfil'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Atualizar perfil',
          ),
        ],
      ),
      body: FutureBuilder<ProfileEnrichment>(
        future: _profileFuture,
        builder: (context, snapshot) {
          final projection = snapshot.hasData
              ? ProfileViewProjection.fromProfile(snapshot.data!.profile)
              : const ProfileViewProjection(
                  generalItems: [],
                  priorityItems: [[], [], [], []],
                  photoUrl: null,
                  completenessScore: 0,
                );
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Center(
                  child: _ProfileAvatar(
                photoUrl: projection.photoUrl,
                onTap: _selectPhoto,
              )),
              const SizedBox(height: 12),
              Text('Completude do perfil',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              LinearProgressIndicator(
                  value: projection.completenessScore / 100),
              const SizedBox(height: 8),
              Text('${projection.completenessScore}%'),
              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),
              if (projection.generalItems.isNotEmpty) ...[
                Text('Dados Gerais',
                    style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                _GeneralDataGrid(items: projection.generalItems),
              ],
              for (var index = 0;
                  index < projection.priorityItems.length;
                  index++)
                if (projection.priorityItems[index].isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Divider(),
                  const SizedBox(height: 12),
                  Text('Prioridade ${index + 1}',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 12),
                  for (final item in projection.priorityItems[index])
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(item.text,
                          style: Theme.of(context).textTheme.titleMedium),
                    ),
                ],
            ],
          );
        },
      ),
    );
  }
}

class _GeneralDataGrid extends StatelessWidget {
  const _GeneralDataGrid({required this.items});

  final List<ProfileViewItem> items;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final item in items)
              SizedBox(
                width: width,
                child: Text(item.text,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
          ],
        );
      },
    );
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.photoUrl, required this.onTap});

  final String? photoUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final source = photoUrl;
    final image = source == null
        ? null
        : source.startsWith('http')
            ? Image.network(source,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _placeholder(context))
            : Image.file(File(source),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _placeholder(context));
    return Semantics(
      button: true,
      label: source == null
          ? 'Adicionar foto do perfil'
          : 'Alterar foto do perfil',
      child: InkResponse(
        onTap: onTap,
        radius: 64,
        child: ClipOval(
          child: SizedBox(
            width: 120,
            height: 120,
            child: image ?? _placeholder(context),
          ),
        ),
      ),
    );
  }

  Widget _placeholder(BuildContext context) => const ColoredBox(
        color: DiabotPalette.surface,
        child: Center(
            child: Icon(Icons.add_a_photo_outlined,
                size: 36, color: DiabotPalette.iconMuted)),
      );
}
