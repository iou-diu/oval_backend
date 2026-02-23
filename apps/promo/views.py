from django.core.exceptions import ValidationError
from django.http import JsonResponse
from django.views.decorators.csrf import csrf_exempt
from django.shortcuts import get_object_or_404
import json

from django.views.generic import TemplateView, ListView, DeleteView
from django.urls import reverse_lazy
from rest_framework import viewsets

from .models import Hotspot, HotspotItem
from ..ecom.models import Product


@csrf_exempt  # Disable CSRF for testing purposes; use proper CSRF handling in production
def create_hotspot_api(request):
    if request.method == 'POST':
        try:
            # Retrieve the title and image from the form
            title = request.POST.get('title')
            image = request.FILES.get('image')
            hotspot_items_data = json.loads(request.POST.get('hotspot_items', '[]'))

            # Check if title and image are provided
            if not title or not image:
                return JsonResponse({'error': 'Title and image are required fields.'}, status=400)

            # Create the Hotspot object
            hotspot = Hotspot.objects.create(title=title, image=image)

            # Create associated HotspotItem objects
            for item in hotspot_items_data:
                HotspotItem.objects.create(
                    hot_spot=hotspot,
                    product_id=item['product_id'],
                    x_coordinate=item['x'],
                    y_coordinate=item['y']
                )

            return JsonResponse({'message': 'Hotspot created successfully!'})

        except json.JSONDecodeError:
            return JsonResponse({'error': 'Invalid JSON in hotspot_items.'}, status=400)

        except ValidationError as e:
            return JsonResponse({'error': str(e)}, status=400)

        except Exception as e:
            return JsonResponse({'error': f'Error: {str(e)}'}, status=500)

    return JsonResponse({'error': 'Invalid request method'}, status=405)


def get_products(request):
    query = request.GET.get('q', '').strip()

    products = Product.objects.all()
    if query:
        products = products.filter(name__icontains=query)
        
    products = products.values('id', 'name')[:50]

    return JsonResponse({
        'products': list(products),
        'total_results': len(products)
    })


class HotspotAddView(TemplateView):
    template_name = 'hotspot.html'

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        context['list_link'] = reverse_lazy('hotspot_list')
        context['page_title'] = 'Hotspot'
        return context

class HotspotListView(ListView):
    model = Hotspot
    template_name = 'promo/hotspot_list.html'
    context_object_name = 'hotspots'

class HotspotDeleteView(DeleteView):
    model = Hotspot
    template_name = 'promo/hotspot_confirm_delete.html'
    success_url = reverse_lazy('hotspot_list')

class HotspotEditView(TemplateView):
    template_name = 'hotspot_edit.html'

    def get_context_data(self, **kwargs):
        context = super().get_context_data(**kwargs)
        hotspot = get_object_or_404(Hotspot, pk=self.kwargs['pk'])
        context['hotspot'] = hotspot
        context['list_link'] = reverse_lazy('hotspot_list')
        context['page_title'] = 'Hotspot'
        
        hotspot_items = []
        for item in hotspot.hot_spot_items.all():
            hotspot_items.append({
                'id': item.id,
                'x': item.x_coordinate,
                'y': item.y_coordinate,
                'product_id': item.product.id if item.product else None,
                'product_name': item.product.name if item.product else '',
            })
        context['hotspot_items_json'] = json.dumps(hotspot_items)
        return context

@csrf_exempt
def edit_hotspot_api(request, pk):
    if request.method == 'POST':
        try:
            hotspot = get_object_or_404(Hotspot, pk=pk)
            title = request.POST.get('title')
            image = request.FILES.get('image')
            hotspot_items_data = json.loads(request.POST.get('hotspot_items', '[]'))

            if not title:
                return JsonResponse({'error': 'Title is required.'}, status=400)

            hotspot.title = title
            if image:
                hotspot.image = image
            hotspot.save()

            hotspot.hot_spot_items.all().delete()

            for item in hotspot_items_data:
                HotspotItem.objects.create(
                    hot_spot=hotspot,
                    product_id=item['product_id'],
                    x_coordinate=item['x'],
                    y_coordinate=item['y']
                )

            return JsonResponse({'message': 'Hotspot updated successfully!'})

        except Exception as e:
            return JsonResponse({'error': f'Error: {str(e)}'}, status=500)

    return JsonResponse({'error': 'Invalid request method'}, status=405)
